# Publishing the orchestrator, and running it on a second machine

The user runs this orchestrator on a second PC, in parallel with this one. That makes the
orchestrator's OWN code a deliverable, with the same discipline as a pull request: it lives in
a private repo, the other machine clones it, and both machines run the same rules.

## The repo holds the CODE, not the state of a machine

`vdirienzo/solidcraft-orch` (private) is the orchestrator's own repository. What goes in it is
the code: `bin/`, `briefs/`, `reports/`, `baseline/`, `workflow.yaml`, the rules and the README.

What stays OUT is the state of a machine. It is regenerated per machine, and committing it puts
one machine's verdicts, locks and slots into the other machine's checkout:

    targets/        # gigabytes of compiled artifacts
    logs/           # transcripts and run logs
    locks/          # who holds what, right now
    gates/          # verdicts of runs that happened HERE
    state/          # the state, split per concept
    state.json      # the state, monolithic
    history.jsonl   # the canonical log of this machine
    slots/
    plan-features.json
    *.bak           # backups of patches
    __pycache__/
    .env            # and anything else that holds a secret

`.gitignore` with those entries, committed with the first commit, so nobody has to remember them.

## A hardcoded path makes the second machine fail

A script with `/home/user/...` inside it does not run on the other PC. Every path comes from a
variable WITH A DEFAULT, so this machine keeps working unchanged and the other one exports its
own:

    ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
    LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
    SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
    WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
    HERMES_SCRIPTS="${HERMES_SCRIPTS:-/home/user/.hermes/scripts}"

The acceptance criterion is one grep, and it is part of the test suite (`bin/test-portability.sh`):

    grep -rn '/home/user' bin/ | grep -v ':-/home/user'    # must be EMPTY

Only the defaults may carry the absolute path. A path outside a default is a bug: it is the one
line that breaks the other machine.

## The knowledge travels with the code

The rules, the traps and the lessons live in the orchestrator's SKILL directory, which the other
machine does not have. They are COPIED into the repo as `docs/`, and the README points there.
The copy is one-directional: `docs/` is a copy, and the skills directory stays the source.

## Scan for secrets BEFORE the first push, and read every hit

The tree is scanned for tokens, keys and private keys before anything is pushed. Two rules about
the scan:

- **A hit that is a self-reference is a FALSE POSITIVE.** `export TOKEN="$TOKEN"` and
  `export TOKEN="${TOKEN:-$(openssl rand -hex 32)}"` contain the NAME of a secret, not a secret.
  A regex that matches `NAME=<16+ chars>` flags them. Read the line before rewriting the script:
  replacing a self-reference with the environment variable changes nothing and destroys a
  working script.
- **A real value never goes into the repo, and it never goes into a script either.** The script
  reads it from the environment; the value lives in the environment of the machine, not in a
  file that gets committed.

The repo is private, but a private repo is not a secret store: the check is cheap and it is the
difference between a token that leaks into a fork and one that does not.

## The second machine registers the crons, not the state

The crons are the parts that make the orchestrator autonomous, and they are the same on both
machines. All of them run with `--no-agent` (zero model tokens) and deliver to `local`:

    hermes cron create --name solidcraft-gate-queue    --schedule '*/3 * * * *' --script gate-queue.sh      --no-agent --deliver local
    hermes cron create --name solidcraft-pipeline      --schedule '*/5 * * * *' --script pipeline.py        --no-agent --deliver local
    hermes cron create --name solidcraft-nice-compilations --schedule '*/2 * * * *' --script nice-compilations.sh --no-agent --deliver local
    hermes cron create --name solidcraft-reporte-diario   --schedule '0 10,22 * * *' --script daily-report.py --no-agent --deliver origin

The wave cron stays PAUSED on both: it opens a new session per run and duplicates the work.

## What the two machines must NOT share

The LOCKS and the slots are per machine. Two machines sharing a lock directory would have one
machine's agent reaping the other's lock, and one machine's gate deleting the target dir the
other is compiling into. Each machine has its own `ORCH_DIR`, its own `LOOP_DIR` and its own
target dirs; what they share is the CODE, the RULES and the FORK.

## The private repo is a backup and a handoff, not a second source of truth

The repo is what the other machine clones and what a new machine starts from. It is NOT where
the running state lives: `state.json` and the verdicts stay on the machine that produced them,
and a machine that clones the repo starts with an empty state and an empty queue.
