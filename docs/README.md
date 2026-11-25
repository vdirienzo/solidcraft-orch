# docs/

The rules of the orchestrator, the traps and the lessons. The rules of SolidCraft are
not here: they live in upstream (see `RULES.md`).

## What to read, in this order

| file | what it is for |
|---|---|
| [`starting-a-session.md`](starting-a-session.md) | how a session starts, and the prompt to paste |
| [`slot-rules.md`](slot-rules.md) | what a slot is, who cleans it, when it may be closed |
| [`known-traps.md`](known-traps.md) | the traps of this machine, one line each |
| [`agent-handover.md`](agent-handover.md) | how a dead agent's work is rescued |
| [`agent-death-and-duplicate-work.md`](agent-death-and-duplicate-work.md) | what to do when two agents did the same thing |
| [`before-dispatching-a-wave-check-for-a-pr.md`](before-dispatching-a-wave-check-for-a-pr.md) | the check before a wave opens a pull request |
| [`verifying-a-delegated-pr.md`](verifying-a-delegated-pr.md) | how to check the work of an agent before merging it |
| [`checking-a-rule-against-real-numbers.md`](checking-a-rule-against-real-numbers.md) | how to measure a rule instead of believing it |
| [`feature-agent-briefs.md`](feature-agent-briefs.md) | the brief of an agent, piece by piece |
| [`issue-selection.md`](issue-selection.md) | how an issue is chosen (and why the kernel ones are parked) |
| [`duplicate-claims-and-contributing-instead.md`](duplicate-claims-and-contributing-instead.md) | what to do when the claim is lost |
| [`costo-de-tokens.md`](costo-de-tokens.md) | what the tokens cost and how to spend them |
| [`disk-hygiene.md`](disk-hygiene.md) | the disk of the slots and the rules of the cleanup |
| [`work-at-risk.md`](work-at-risk.md) | the work that only exists on this machine |
| [`portable-orchestrator.md`](portable-orchestrator.md) | how to move the orchestrator to another machine |
| [`visual-evidence-capture.md`](visual-evidence-capture.md) | how to take the pictures a UI change needs |
| [`loop-vs-graph.md`](loop-vs-graph.md) | the loop and the graph of the process |
| [`la-otra-mitad.md`](la-otra-mitad.md) | the other half of the orchestrator (`loop/`) |
| [`a-pr-can-be-a-no-op.md`](a-pr-can-be-a-no-op.md) | when a pull request changes nothing |

## Historical data (2026-11-21 and before)

- `reports/agentes-metricas.csv` is **historical**: it is 132 delegations to hermes subagents,
  versioned on 2026-11-04 (the `estado` column says `interrupted`, `max_iterations`,
  `completed`). It is useful to compare, and it does not describe the loop of today: the
  agent is opencode with a time ceiling (`AGENT_TIMEOUT_MIN`), and what each turn did and
  cost is in `logs/<N>-wave.log` and `logs/<N>-wave.jsonl`. The CSV is not edited.

- The lessons of the last two days, with the measurements, are in
  [`../reports/lecciones-2026-11-22.md`](../reports/lecciones-2026-11-22.md); what the
  session of the 23-11 did is in
  [`../reports/sesion-2026-11-23.md`](../reports/sesion-2026-11-23.md).
