# Loop or graph? The orchestration architecture, decided

The question "should this become a LangGraph/AutoGen state machine?" hides TWO different
questions, and they have opposite answers.

## The AGENT's loop stays a loop

An agent's inner cycle is `think -> tool -> observe -> think`, with two exits (done, out of
budget). Its state IS the conversation. A graph framework would re-express the same machine with
more code and a dependency, and it would not make the agent write any more often — the thing
that decides that is the SHAPE of the brief, not the shape of the runtime.

## The ORCHESTRATOR's flow is a graph, and it is ALREADY one

The flow that turns an issue into a merged PR has real branches (free / claimed / dead),
real error paths (a gate that fails, a claim lost, a cause in a paused area), real retries, and
real state that has to survive between steps. It is implemented as a graph whose nodes are
processes and whose edges live in files on disk: the sweep and the pick, the claim check, the
brief, the agent's commit, the draft PR, the gate queue, the verdict, the promotion to ready.

**That durability is the whole point, and it is what a framework would take away.** A gate
compiles Rust for 40 minutes. A PR waits on the maintainer for days. The flow has to survive a
crash of the process, a cron firing every three minutes, a session that ends, and a reboot.
An in-memory graph loses all of it on exit.

## The criteria, applied

| Criterion | The agent's loop | The orchestrator's flow |
|---|---|---|
| Branching | none: two exits | many, and they are the work |
| State across steps | the conversation | files on disk, read by many processes |
| Conditions | done / out of budget | free, claimed, dead, parked, red, stale, failed |
| Error recovery | none needed | salvage, retry, re-verify, re-queue |
| Scaling | the context window | concurrent slots, a queue, several machines |
| Debuggability | one transcript | needs the graph DECLARED to be readable |
| Over-engineering risk | high: a graph here is pure ceremony | low: the complexity is already paid for in code |

## The improvement is to DECLARE the graph, not to re-implement it

The real defect of a many-script orchestrator is not that it lacks a framework: it is that its
flow is IMPLICIT — inside the scripts and inside the operator's head — so nobody can answer
"what is the next step" or "where did this get stuck" without reconstructing the state by hand.

So:

1. `workflow.yaml` names the nodes, their preconditions, what each reads and writes, what to do
   when it fails, and the edges between them.
2. A validator checks the declaration, WITH A NEGATIVE TEST: it has to FAIL on a broken graph,
   because a validator that only ever passes protects nothing.
3. A runner executes the node that is eligible. It does NOT run the nodes that compile: those
   belong to the queue and to its cron.

The declaration is the deliverable. The framework is not.

## What a migration would have cost

- The state would move into one long-running process's memory, which is the opposite of what a
  40-minute gate and a multi-day PR wait need.
- The lock, the queue, the cron and the per-slot target dir — the parts that already make the
  flow survive — would have to be reimplemented inside the framework's own abstractions.
- The dependency would land on a box whose real constraint is CPU and RAM for Rust, not for
  orchestration.
- The measured failure mode of this loop was AGENTS THAT WRITE NOTHING and BASELINES THAT GO
  STALE. Neither is fixed by a different runtime.

## What to do instead, in order

1. Declare the graph (`workflow.yaml`) — cheap, and it makes the flow reviewable.
2. One authority per concept (one script decides who holds a claim; the others delegate).
3. Split the monolithic state into one file per concept, with a check that proves the split
   changed nothing.
4. Parameterise the paths so the loop runs on a second machine.

Then keep the loop. The measured numbers do not support the change: the cost per attempt is the
same for issues and features, and what differs is the DELIVERY rate — a shape problem, fixed by
the brief and the issue choice, not by the runtime.
